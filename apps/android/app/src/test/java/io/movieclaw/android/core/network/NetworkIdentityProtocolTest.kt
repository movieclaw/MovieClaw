package io.movieclaw.android.core.network

import android.app.Application
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.session.DeepLinkBus
import io.movieclaw.android.core.session.LibraryHomeSnapshotStore
import io.movieclaw.android.core.session.SessionCacheCleaner
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.TokenVault
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog

/** 用真实 HTTP 请求验证认证边界、Cookie 协议和异步身份变化，不只断言辅助函数。 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class NetworkIdentityProtocolTest {
    private lateinit var server: MockWebServer
    private lateinit var vault: TokenVault
    private lateinit var client: OkHttpClient
    private lateinit var factory: ApiFactory
    private val json = NetworkModule.json()

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        vault = TokenVault(RuntimeEnvironment.getApplication())
        client = OkHttpClient.Builder().addInterceptor(authInterceptor(vault)).build()
        factory = ApiFactory(json, client, client, vault, ShareCookieJar())
    }

    @After fun tearDown() { server.shutdown() }
    private fun origin(): String = server.url("/").toString().trimEnd('/')

    @Test fun `discovery source selection uses provider query and decodes selected feed`() = runBlocking {
        listOf("tmdb", "douban").forEach { provider ->
            server.enqueue(envelope("""{"provider":"$provider","media_type":"movie","sections":[{"collection_ref":"$provider:movie:hot","title":"热门"}]}"""))
            val page = factory.forOrigin(origin()).discoveryPage("movie", source = provider).dataOrThrow()
            val request = server.takeRequest()
            assertEquals("/api/v1/ui/discovery/movie", request.requestUrl!!.encodedPath)
            assertEquals(provider, request.requestUrl!!.queryParameter("provider"))
            assertNull(request.requestUrl!!.queryParameter("source"))
            assertEquals(provider, page.provider)
            assertEquals("$provider:movie:hot", page.sections.single().collectionRef)
        }
    }
    private fun envelope(data: String) = MockResponse().setBody("""{"success":true,"code":"OK","message":"","data":$data}""")

    @Test fun `error logging preserves status and path without credentials or response body`() {
        ShadowLog.clear()
        server.enqueue(MockResponse().setResponseCode(503)
            .setBody("echo token=response-token password=response-password"))
        val url = server.url("/api/v1/playback/start").newBuilder()
            .username("private-user")
            .password("userinfo-password")
            .addQueryParameter("token", "signed-token")
            .addQueryParameter("password", "query-password")
            .fragment("private-fragment")
            .build()
        NetworkModule.generalClient(vault).newCall(Request.Builder().url(url).build()).execute().use {
            assertEquals(503, it.code)
            assertTrue(it.body!!.string().contains("response-token"))
        }
        val logs = ShadowLog.getLogsForTag("McHttp").joinToString("\n") { it.msg }
        assertTrue(logs.contains("503 GET"))
        assertTrue(logs.contains("/api/v1/playback/start"))
        listOf("token", "password", "private-user", "private-fragment", "echo").forEach {
            assertFalse("log leaked $it: $logs", logs.contains(it))
        }
    }

    @Test fun `untrusted prefix host never receives member bearer`() {
        vault.activate("https://nas.example", "alice", "secret-token")
        // 模拟 DNS：保留恶意主机供认证拦截器判断，之后把传输路由到本地服务器采集真实头。
        val routingClient = identityClient(client, vault.snapshot()).newBuilder().addInterceptor(Interceptor { chain ->
            chain.proceed(chain.request().newBuilder().url(server.url("/api/v1/health")).build())
        }).build()
        server.enqueue(MockResponse().setBody("{}"))
        routingClient.newCall(Request.Builder().url("https://nas.example.evil/api/v1/health").build()).execute().close()
        assertNull(server.takeRequest().getHeader("Authorization"))
        assertFalse(sameOrigin("https://nas.example:444/api/v1/auth/me".toHttpUrl(), "https://nas.example"))
        assertFalse(sameOrigin("http://nas.example/api/v1/auth/me".toHttpUrl(), "https://nas.example"))
    }

    @Test fun `api created before switch keeps its original token`() = runBlocking {
        vault.activate(origin(), "alice", "alice-token")
        val aliceApi = factory.forOrigin(origin())
        vault.activate(origin(), "bob", "bob-token")
        server.enqueue(envelope("""{"username":"alice"}"""))
        aliceApi.me().dataOrThrow()
        assertEquals("Bearer alice-token", server.takeRequest().getHeader("Authorization"))
        server.enqueue(envelope("""{"username":"bob"}"""))
        factory.forOrigin(origin()).me().dataOrThrow()
        assertEquals("Bearer bob-token", server.takeRequest().getHeader("Authorization"))
    }

    @Test fun `share unlock cookie is replayed only on its guest path without member token`() = runBlocking {
        vault.activate(origin(), "alice", "member-secret")
        val guest = factory.guestForOrigin(origin())
        server.enqueue(envelope("""{"requires_password":true,"unlocked":true}""")
            .addHeader("Set-Cookie", "movieclaw_share=guest-grant; Path=/api/v1/share/locked; HttpOnly; SameSite=Lax"))
        guest.shareUnlock("locked", io.movieclaw.android.core.model.ShareUnlockRequest("password")).dataOrThrow()
        val unlock = server.takeRequest()
        assertNull(unlock.getHeader("Authorization"))
        assertTrue(unlock.body.readUtf8().contains("password"))
        server.enqueue(envelope("""{"requires_password":true,"unlocked":true}"""))
        guest.sharePublic("locked").dataOrThrow()
        val probe = server.takeRequest()
        assertEquals("movieclaw_share=guest-grant", probe.getHeader("Cookie"))
        assertNull(probe.getHeader("Authorization"))
        // 浏览器 Cookie 不区分端口；原生分享凭据额外绑定完整 origin，隔离同主机另一服务。
        val otherPort = server.url("/api/v1/share/locked").newBuilder().port(server.port + 1).build()
        assertTrue(factory.guestClient.cookieJar.loadForRequest(otherPort).isEmpty())
        server.enqueue(envelope("""{"requires_password":true,"unlocked":true}"""))
        factory.guestPlaybackForOrigin(origin()).sharePublic("locked").dataOrThrow()
        val playback = server.takeRequest()
        assertEquals("movieclaw_share=guest-grant", playback.getHeader("Cookie"))
        assertNull(playback.getHeader("Authorization"))
        server.enqueue(MockResponse().setBody("image-bytes"))
        factory.guestClient.newCall(Request.Builder().url(server.url("/api/v1/share/locked/artwork")).build()).execute().close()
        val image = server.takeRequest()
        assertEquals("movieclaw_share=guest-grant", image.getHeader("Cookie"))
        assertNull(image.getHeader("Authorization"))
        server.enqueue(envelope("""{"requires_password":false,"unlocked":true}"""))
        guest.sharePublic("other").dataOrThrow()
        assertNull(server.takeRequest().getHeader("Cookie"))
        server.enqueue(envelope("""{"username":"alice"}"""))
        factory.forOrigin(origin()).me().dataOrThrow()
        val member = server.takeRequest()
        assertNull(member.getHeader("Cookie"))
        assertEquals("Bearer member-secret", member.getHeader("Authorization"))
    }

    @Test fun `changed proxy api base replaces cached retrofit`() = runBlocking {
        server.enqueue(envelope("""{"initialized":true}"""))
        factory.forOrigin(origin()).bootstrapStatus().dataOrThrow()
        assertEquals("/api/v1/auth/bootstrap", server.takeRequest().path)
        factory.registerApiBase(origin(), origin() + "/movieclaw/api/v1")
        server.enqueue(envelope("""{"initialized":true}"""))
        factory.forOrigin(origin()).bootstrapStatus().dataOrThrow()
        assertEquals("/movieclaw/api/v1/auth/bootstrap", server.takeRequest().path)
    }

    @Test fun `explicit reverse proxy path is used for anonymous login negotiation`() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val cleaners = SessionCacheCleaner(context, ImageLoaders(context, vault, client, ShareCookieJar()), LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, factory, client, cleaners)
        server.enqueue(MockResponse().setBody("""{"service":"movieclaw","spec_hash":"test"}"""))
        server.enqueue(envelope("""{"initialized":true}"""))
        server.enqueue(envelope("""{"token":"new-token","session":{"username":"alice"}}"""))
        // Robolectric 没有硬件 Keystore；本测试验证服务端协商，持久凭据另有拒写用例。
        runCatching { repository.login(server.url("/movieclaw/").toString(), "alice", "password") }
        val health = server.takeRequest(3, TimeUnit.SECONDS)!!
        val bootstrap = server.takeRequest(3, TimeUnit.SECONDS)!!
        val login = server.takeRequest(3, TimeUnit.SECONDS)!!
        assertEquals("/movieclaw/api/v1/health", health.path)
        assertEquals("/movieclaw/api/v1/auth/bootstrap", bootstrap.path)
        assertEquals("/movieclaw/api/v1/auth/device/login", login.path)
        assertNull(login.getHeader("Authorization"))
        assertEquals(origin() + "/movieclaw/api/v1", factory.apiBaseOf(origin()))
        val payload = json.parseToJsonElement(login.body.readUtf8()).toString()
        assertTrue(payload.contains("installation_id"))
        assertTrue(payload.contains("android"))
    }

    private suspend fun staleRevalidation(response: MockResponse) {
        val context = RuntimeEnvironment.getApplication()
        val cleaners = SessionCacheCleaner(context, ImageLoaders(context, vault, client, ShareCookieJar()), LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, factory, client, cleaners)
        vault.activate(origin(), "alice", "alice-token")
        val requested = CountDownLatch(1)
        val release = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requested.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return response
            }
        }
        kotlinx.coroutines.coroutineScope {
            val oldRequest = async(Dispatchers.IO) { repository.revalidate(origin()) }
            assertTrue(requested.await(5, TimeUnit.SECONDS))
            vault.activate(origin(), "bob", "bob-token")
            // 安排真实的 READY/bob 页面状态；不走设备登录，避免测试依赖模拟器 Keystore。
            val field = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            val state = field.get(repository) as kotlinx.coroutines.flow.MutableStateFlow<io.movieclaw.android.core.session.SessionUi>
            state.value = io.movieclaw.android.core.session.SessionUi(
                phase = io.movieclaw.android.core.session.SessionPhase.READY,
                origin = origin(), session = io.movieclaw.android.core.model.SessionView("bob", role = "member"),
            )
            release.countDown()
            oldRequest.await()
        }
        assertEquals("bob-token", vault.activeToken())
        assertEquals("bob", repository.ui.value.session?.username)
        assertEquals("member", repository.ui.value.session?.role)
        assertEquals(io.movieclaw.android.core.session.SessionPhase.READY, repository.ui.value.phase)
    }

    @Test fun `old successful me cannot replace newly activated account`() = runBlocking {
        staleRevalidation(envelope("""{"username":"alice","role":"admin"}"""))
    }

    @Test fun `old unauthorized me cannot revoke newly activated account`() = runBlocking {
        staleRevalidation(MockResponse().setResponseCode(401).setBody("""{"success":false,"code":"UNAUTHORIZED","message":"expired"}"""))
    }

    @Test fun `unavailable keystore refuses token without memory or plaintext fallback`() = runBlocking {
        val previous = java.security.Security.getProvider("AndroidKeyStore")
        java.security.Security.removeProvider("AndroidKeyStore")
        try {
            try {
                vault.saveToken(origin(), "alice", "must-not-persist")
                fail("Keystore failure must not silently persist a plaintext token")
            } catch (expected: IllegalStateException) {
                assertTrue(expected.message!!.contains("安全存储"))
            }
            assertNull(vault.token(origin(), "alice"))
        } finally {
            if (previous != null) java.security.Security.addProvider(previous)
        }
    }

    private fun events(): EventStream {
        val context = RuntimeEnvironment.getApplication()
        val cleaners = SessionCacheCleaner(context, ImageLoaders(context, vault, client, ShareCookieJar()), LibraryHomeSnapshotStore(context, json))
        return EventStream(client, SessionRepository(context, json, vault, factory, client, cleaners), factory)
    }

    @Test fun `already connected sse cannot publish old account events after switch`() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val cleaners = SessionCacheCleaner(context, ImageLoaders(context, vault, client, ShareCookieJar()), LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, factory, client, cleaners)
        val field = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val state = field.get(repository) as kotlinx.coroutines.flow.MutableStateFlow<io.movieclaw.android.core.session.SessionUi>
        state.value = io.movieclaw.android.core.session.SessionUi(phase = io.movieclaw.android.core.session.SessionPhase.READY,
            origin = origin(), session = io.movieclaw.android.core.model.SessionView("alice"))
        vault.activate(origin(), "alice", "alice-token")
        val requested = CountDownLatch(1)
        val release = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requested.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return MockResponse().addHeader("Content-Type", "text/event-stream")
                    .setBody("event: done\ndata: {}\n\n")
            }
        }
        val received = mutableListOf<SseEvent>()
        val error = kotlinx.coroutines.coroutineScope {
            val collection = async(Dispatchers.IO) {
                runCatching { EventStream(client, repository, factory).reliableEvents("events").collect { received += it } }
            }
            assertTrue(requested.await(5, TimeUnit.SECONDS))
            vault.activate(origin(), "bob", "bob-token")
            release.countDown()
            collection.await().exceptionOrNull()
        }
        assertEquals("SESSION_CHANGED", (error as? ApiException)?.code)
        assertTrue(received.isEmpty())
        assertEquals("Bearer alice-token", server.takeRequest().getHeader("Authorization"))
    }

    @Test fun `sse terminal closes immediately instead of waiting for server eof`() = runBlocking {
        // 终态后服务端仍继续推字节；客户端应只交付 done，并取消流。
        server.enqueue(MockResponse().addHeader("Content-Type", "text/event-stream")
            .setBody("id: 1\nevent: done\ndata: {}\n\n" + ": heartbeat\n\n".repeat(1000))
            .throttleBody(64, 1, TimeUnit.SECONDS))
        val result = kotlinx.coroutines.withTimeout(3000) {
            val received = mutableListOf<SseEvent>()
            events().streamOnce(identityClient(client, null), origin() + "/api/v1", "events", null, setOf("done"))
                .collect { received += it }
            received
        }
        assertEquals(listOf("done"), result.map { it.name })
    }

    @Test fun `sse buffer overflow reports an error instead of silently skipping deltas`() = runBlocking {
        server.enqueue(MockResponse().addHeader("Content-Type", "text/event-stream")
            .setBody((1..200).joinToString("") { "id: $it\nevent: text_delta\ndata: {}\n\n" }))
        var error: Throwable? = null
        try {
            kotlinx.coroutines.withTimeout(10_000) {
                events().streamOnce(identityClient(client, null), origin() + "/api/v1", "events", null, emptySet())
                    .collect { kotlinx.coroutines.delay(10) }
            }
        } catch (failure: ApiException) { error = failure }
        assertEquals("SSE_BACKPRESSURE", (error as? ApiException)?.code)
    }

    @Test fun `closing a share allows opening the same link again`() {
        val bus = DeepLinkBus()
        val link = bus.parse("movieclaw://share/locked?origin=" + java.net.URLEncoder.encode(origin(), "UTF-8"))!!
        bus.publish(link)
        val context = RuntimeEnvironment.getApplication()
        val cleaners = SessionCacheCleaner(context, ImageLoaders(context, vault, client, ShareCookieJar()), LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, factory, client, cleaners)
        val field = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val state = field.get(repository) as kotlinx.coroutines.flow.MutableStateFlow<io.movieclaw.android.core.session.SessionUi>
        state.value = io.movieclaw.android.core.session.SessionUi(phase = io.movieclaw.android.core.session.SessionPhase.NEEDS_LOGIN)
        val root = io.movieclaw.android.routing.RootViewModel(repository, io.movieclaw.android.core.designsystem.FeedbackBus(),
            bus, io.movieclaw.android.core.session.SearchAccessRepository(factory, repository))
        root.dismissShare(link.slug)
        assertNull(bus.pendingShare.value)
        bus.publish(link)
        assertEquals(link, bus.pendingShare.value)
    }

    @Test fun `discover filter sends server parameter names and repeats genre ids`() = runBlocking {
        // 服务端契约（OpenAPI / iOS 生成客户端 / 网页同口径）：`genre_ids` 是**重复参数**、
        // `origin_country` / `rating_gte` / `runtime_lte`；这条路由是 TMDB 专属，没有 provider/source。
        // 此前安卓发的是 genres（逗号串）/ country / rating / runtime —— 服务端对不认识的参数
        // 静默忽略，表现就是「筛选条件点了没反应」（PR #2 讨论里抓到的）。
        server.enqueue(envelope("{}"))
        factory.forOrigin(origin()).discoverTitles(
            mediaType = "movie",
            genreIds = listOf("35", "18"),
            originCountry = "CN",
            year = "2024",
            ratingGte = "7",
            runtimeLte = "120",
            sort = "rating",
            page = 2,
        ).dataOrThrow()
        val url = server.takeRequest().requestUrl!!
        assertEquals("/api/v1/discover/titles", url.encodedPath)
        assertEquals(listOf("35", "18"), url.queryParameterValues("genre_ids"))
        assertEquals("CN", url.queryParameter("origin_country"))
        assertEquals("2024", url.queryParameter("year"))
        assertEquals("7", url.queryParameter("rating_gte"))
        assertEquals("120", url.queryParameter("runtime_lte"))
        assertEquals("rating", url.queryParameter("sort"))
        assertEquals("2", url.queryParameter("page"))
        listOf("source", "provider", "genres", "country", "rating", "runtime").forEach {
            assertNull("这条路由不认这个参数，发了也没用：$it", url.queryParameter(it))
        }
    }
}
