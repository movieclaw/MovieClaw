package io.movieclaw.android.core.session

import android.app.Application
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.discovery.ServerDiscovery
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.feature.onboarding.LoginViewModel
import io.movieclaw.core.network.OkHttpTransport
import io.movieclaw.core.network.ServerAddress
import io.movieclaw.core.network.UnreachableException
import io.movieclaw.core.network.generated.McApi
import java.security.cert.CertificateExpiredException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 从登录表单提交到真实 HTTPS 探测及错误显示；不替换证书校验或域名校验。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class LoginTlsTest {
    private fun repository(client: OkHttpClient): SessionRepository {
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        return SessionRepository(context, json, vault, ApiFactory(json, client, client, vault, cookies), client,
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { error("A failed TLS probe must not activate a session") })
    }

    @Test fun loginProbePreservesTheOriginalException() = runBlocking {
        val failure = SSLHandshakeException("validation failed").apply { initCause(CertificateExpiredException()) }
        val client = OkHttpClient.Builder().addInterceptor { throw failure }.build()
        val repository = repository(client)
        for (createAdmin in listOf(false, true)) {
            val result = runCatching {
                if (createAdmin) repository.createAdminAndLogin("https://nas.example.xyz:6688", "alice", "secret")
                else repository.login("https://nas.example.xyz:6688", "alice", "secret")
            }
            // 协程的 stack-trace recovery 可复制异常，但原始异常仍应保留在 cause 链中。
            assertTrue(generateSequence(result.exceptionOrNull()) { it.cause }.any { it === failure })
            assertTrue(friendlyMessage(result.exceptionOrNull()!!).contains("证书已过期"))
        }
    }

    @Test fun trustedCertificateAllowsHealthAndBootstrapOverHttps() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(ca.certificate).build()
        val client = OkHttpClient.Builder().sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build()
        MockWebServer().use { server ->
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.start()
            server.enqueue(MockResponse().setBody("""{"service":"movieclaw","status":"ok"}"""))
            server.enqueue(MockResponse().setBody("""{"success":true,"data":{"initialized":false}}"""))
            val failure = runCatching { repository(client).login(server.url("/").toString(), "alice", "secret") }.exceptionOrNull()
            assertTrue(failure is io.movieclaw.android.core.network.SetupRequiredException)
            assertEquals("/api/v1/health", server.takeRequest(2, TimeUnit.SECONDS)!!.path)
            assertEquals("/api/v1/auth/bootstrap", server.takeRequest(2, TimeUnit.SECONDS)!!.path)
            assertEquals(2, server.requestCount)
        }
    }

    @Test fun loginFormAndTvTransportReportRealCertificateFailures() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val ca = HeldCertificate.Builder().certificateAuthority(1).build()
        val now = System.currentTimeMillis()
        try {
            for ((name, expected) in listOf(
                "unknown-ca" to "证书不受信任或证书链不完整",
                "expired" to "证书已过期",
                "hostname" to "证书与服务器域名不匹配",
                "incomplete-chain" to "证书不受信任或证书链不完整",
            )) {
                val intermediate = HeldCertificate.Builder().certificateAuthority(0).signedBy(ca).build()
                val cert = HeldCertificate.Builder()
                    .commonName("MovieClaw TLS test")
                    .addSubjectAlternativeName(if (name == "hostname") "other.example.xyz" else "localhost")
                    .signedBy(if (name == "incomplete-chain") intermediate else ca)
                    .apply { if (name == "expired") validityInterval(now - 172_800_000, now - 86_400_000) }
                    .build()
                val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
                val clientTls = HandshakeCertificates.Builder()
                    .addTrustedCertificate(if (name == "unknown-ca") HeldCertificate.Builder().certificateAuthority(0).build().certificate else ca.certificate)
                    .build()
                val client = OkHttpClient.Builder().sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager)
                    .callTimeout(5, TimeUnit.SECONDS).build()
                MockWebServer().use { server ->
                    server.useHttps(serverTls.sslSocketFactory(), false)
                    server.start()
                    // A TLS failure must stop before health/bootstrap/password requests reach the server.
                    server.enqueue(MockResponse().setBody("""{"service":"movieclaw","status":"ok"}"""))
                    val repository = repository(client)
                    val vm = LoginViewModel(repository, ServerDiscovery(RuntimeEnvironment.getApplication(), client))
                    try {
                        vm.onServer(server.url("/").toString())
                        vm.onUsername("alice")
                        vm.onPassword("secret")
                        vm.submit()
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
                        do {
                            runCurrent()
                            Thread.sleep(10)
                        } while (vm.ui.value.loading && System.nanoTime() < deadline)
                        assertFalse("$name: login did not complete", vm.ui.value.loading)
                        assertTrue("$name: ${vm.ui.value.error}", vm.ui.value.error?.contains(expected) == true)
                        assertFalse(vm.ui.value.loggedIn)
                        assertNotEquals(SessionPhase.READY, repository.ui.value.phase)
                        val api = McApi(OkHttpTransport(ServerAddress.parse(server.url("/").toString())!!.apiBase, client))
                        val failure = runCatching { api.healthCheck() }.exceptionOrNull()
                        assertTrue("$name: $failure", failure is UnreachableException)
                        assertTrue(failure!!.message!!.contains(expected))
                        assertFalse(failure.message!!.contains("http"))
                        assertEquals(0, server.requestCount)
                    } finally {
                        androidx.lifecycle.ViewModelStore().apply { put("login", vm); clear() }
                        runCurrent()
                    }
                }
            }
        } finally {
            Dispatchers.resetMain()
        }
    }
}
