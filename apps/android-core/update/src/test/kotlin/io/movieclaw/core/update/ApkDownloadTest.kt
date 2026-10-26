package io.movieclaw.core.update

import io.movieclaw.core.model.generated.ClientReleaseView
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.security.MessageDigest

class ApkDownloadTest {
    @get:Rule val tmp = TemporaryFolder()
    private val server = MockWebServer()
    private val apk = ByteArray(300_000) { (it % 251).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(apk).joinToString("") { "%02x".format(it) }
    private val release = ClientReleaseView(product = "androidtv", version = "0.3.0", build = 4, size = apk.size.toLong(), sha256 = sha.uppercase())

    @Before fun setUp() = server.start()
    @After fun tearDown() = server.close()

    private fun serve(bytes: ByteArray) = server.enqueue(MockResponse.Builder().code(200).body(Buffer().write(bytes)).build())

    @Test fun `downloads through the server with the bearer and verifies sha256`() = runTest {
        serve(apk)
        val progress = mutableListOf<Float>()
        val file = ApkDownload.fetch(OkHttpClient(), ApkDownload.serverUrl(server.url("/api/v1/"), "androidtv"), "tok", release, tmp.root) { progress += it }
        assertArrayEquals(apk, file.readBytes())
        val request = server.takeRequest()
        assertEquals("/api/v1/app/clients/androidtv/apk", request.url.encodedPath)
        assertEquals("Bearer tok", request.headers["Authorization"])
        assertEquals(1f, progress.last())
        // 同一版再下：直接复用，不再请求
        ApkDownload.fetch(OkHttpClient(), ApkDownload.serverUrl(server.url("/api/v1/"), "androidtv"), "tok", release, tmp.root)
        assertEquals(1, server.requestCount)
    }

    @Test fun `a tampered package is thrown away`() = runTest {
        serve(apk.copyOf().also { it[10] = 0 })
        val error = runCatching { ApkDownload.fetch(OkHttpClient(), ApkDownload.serverUrl(server.url("/api/v1/"), "androidtv"), null, release, tmp.root) }.exceptionOrNull()
        assertTrue(error is IOException && error.message!!.contains("校验失败"))
        assertFalse(tmp.root.listFiles()!!.any { it.name.endsWith(".apk") || it.name.endsWith(".part") })
    }

    @Test fun `server error text is shown as is`() = runTest {
        server.enqueue(MockResponse.Builder().code(400).body("""{"code":"BAD_REQUEST","message":"无法连接 GitHub 检查客户端更新"}""").build())
        val error = runCatching { ApkDownload.fetch(OkHttpClient(), ApkDownload.serverUrl(server.url("/api/v1/"), "androidtv"), null, release, tmp.root) }.exceptionOrNull()
        assertEquals("无法连接 GitHub 检查客户端更新", error?.message)
    }
}
