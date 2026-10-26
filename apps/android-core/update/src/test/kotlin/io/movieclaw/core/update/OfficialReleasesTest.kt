package io.movieclaw.core.update

import kotlinx.coroutines.test.runTest
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException

class OfficialReleasesTest {
    private val server = MockWebServer()
    private val routes = mutableMapOf<String, String>()

    @Before fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = routes[request.url.encodedPath] ?: return MockResponse.Builder().code(404).build()
                return MockResponse.Builder().code(200).body(body).build()
            }
        }
        server.start()
    }

    @After fun tearDown() = server.close()

    private fun url(path: String) = server.url(path).toString()

    @Test fun `picks the highest published android tag and reads its package info`() = runTest {
        routes["/repo/git/matching-refs/tags/android-v"] = """[
            {"ref":"refs/tags/android-v0.3.1"},{"ref":"refs/tags/android-v0.4.0"},
            {"ref":"refs/tags/android-v0.10.0"},{"ref":"refs/tags/android-v0.11.0-beta.1"}]"""
        // 0.10.0 还是草稿（匿名 404）→ 退到 0.4.0；0.11.0-beta.1 是预发布 tag，不看
        routes["/repo/releases/tags/android-v0.4.0"] = """{
            "tag_name":"android-v0.4.0","draft":false,"prerelease":false,"body":"## 0.4.0","html_url":"https://x/r",
            "published_at":"2026-10-16T00:57:29Z","assets":[
              {"name":"MovieClaw-Android-arm64.apk","browser_download_url":"${url("/dl/a.apk")}"},
              {"name":"MovieClaw-Android-arm64.json","browser_download_url":"${url("/dl/a.json")}"}]}"""
        routes["/dl/a.json"] = """{"product":"android","version":"0.4.0","build":"30000007","size":27598601,
            "sha256":"4F51","certificateSha256":"18042f","minimumSdk":26,"asset":"MovieClaw-Android-arm64.apk"}"""
        val found = OfficialReleases("android", OkHttpClient(), url("/repo").trimEnd('/')).latest()
        assertEquals("0.4.0", found.release.version)
        assertEquals(30000007L, found.release.build)
        assertEquals("4f51", found.release.sha256)
        assertEquals("## 0.4.0", found.release.changelog)
        assertEquals(url("/dl/a.apk"), found.apkUrl)
    }

    @Test fun `no published release is an error so the caller falls back to the server`() = runTest {
        routes["/repo/git/matching-refs/tags/androidtv-v"] = "[]"
        val error = runCatching { OfficialReleases("androidtv", OkHttpClient(), url("/repo").trimEnd('/')).latest() }.exceptionOrNull()
        assertTrue(error is IOException)
    }
}
