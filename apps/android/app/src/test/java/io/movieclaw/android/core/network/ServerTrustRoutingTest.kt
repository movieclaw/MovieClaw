package io.movieclaw.android.core.network

import android.app.Application
import io.movieclaw.android.core.session.TokenVault
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * PR #1001 评审问题 1、2 的回归测试：
 * - 选路到「内网/外网另一个主机」后，成员请求仍要带 Bearer（只对已验证的入口放行）；
 * - 竞速在全部候选失败时要能返回，不会永久挂着。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class ServerTrustRoutingTest {
    private lateinit var server: MockWebServer
    private lateinit var vault: TokenVault
    private lateinit var base: OkHttpClient

    @Before fun setUp() {
        ServerTrust.clear()
        server = MockWebServer().also { it.start() }
        vault = TokenVault(RuntimeEnvironment.getApplication())
        base = OkHttpClient.Builder()
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .addInterceptor(authInterceptor(vault))
            .build()
    }

    @After fun tearDown() {
        ServerTrust.clear()
        server.shutdown()
    }

    /** 身份在**发起请求时**绑定（与 ApiFactory 的用法一致），不能在 activate 之前取快照 */
    private fun callOnce(): okhttp3.Response {
        server.enqueue(MockResponse().setBody("{}"))
        return identityClient(base, vault.snapshot())
            .newCall(Request.Builder().url(server.url("/api/v1/auth/session")).build())
            .execute()
    }

    @Test fun `routed host gets bearer only after it is verified and trusted`() {
        val loginOrigin = "http://192.168.1.10:3010"
        val wanOrigin = server.url("/").toString().trimEnd('/')
        vault.activate(loginOrigin, "alice", "alice-token")

        // 未登记：换到另一个主机（未验证）时不能把令牌发过去
        callOnce().use { resp ->
            assertNotNull(resp)
        }
        val untrusted = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertNull("未验证的入口不能携带 Bearer", untrusted.getHeader("Authorization"))

        // 登记（模拟 /health 的 instance_id + proof 校验通过后）→ 同一主机应带 Bearer
        ServerTrust.allow(loginOrigin, listOf(loginOrigin, wanOrigin))
        callOnce().use { assertNotNull(it) }
        val trusted = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("Bearer alice-token", trusted.getHeader("Authorization"))
    }

    @Test fun `raceFirst returns null when every probe fails`() = runBlocking {
        val started = System.currentTimeMillis()
        val winner = raceFirst(
            lan = listOf("lan-a", "lan-b"),
            wan = listOf("wan-a"),
            timeoutMs = 400,
            probe = { _, _ -> false },
            lanTimeoutMs = 50,
            wanTimeoutMs = 80,
            wanDelayMs = 20,
        )
        val elapsed = System.currentTimeMillis() - started
        assertNull(winner)
        assertTrue("全部失败要在超时附近返回，实际 ${elapsed}ms", elapsed < 3_000)
    }

    @Test fun `raceFirst returns the first successful candidate`() = runBlocking {
        val winner = raceFirst(
            lan = listOf("slow", "fast"),
            wan = emptyList<String>(),
            timeoutMs = 1_000,
            probe = { candidate, _ ->
                if (candidate == "fast") {
                    true
                } else {
                    kotlinx.coroutines.delay(500); false
                }
            },
            lanTimeoutMs = 1_000,
        )
        assertEquals("fast", winner)
    }

    @Test fun `content range total is parsed without off by one`() {
        assertEquals(1000L, io.movieclaw.android.core.offline.parseContentRangeTotal("bytes 0-999/1000"))
        assertEquals(312733770L, io.movieclaw.android.core.offline.parseContentRangeTotal("bytes 100-999/312733770"))
        assertNull(io.movieclaw.android.core.offline.parseContentRangeTotal("bytes 0-99/*"))
        assertNull(io.movieclaw.android.core.offline.parseContentRangeTotal(null))
        assertNull(io.movieclaw.android.core.offline.parseContentRangeTotal("garbage"))
    }
}
