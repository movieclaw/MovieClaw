package io.movieclaw.android.core.network

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

/**
 * 请求级故障转移的判定（docs/design/server-addresses.md §4.6）：
 * 只有「换地址可能有用」的硬错误才切换；超时与 DNS 失败属于软错误，照旧重试/累计。
 */
class HttpFailoverTest {

    @Test
    fun `硬错误才换地址`() {
        assertTrue(isHardNetworkFailure(ConnectException("refused")))
        assertTrue(isHardNetworkFailure(NoRouteToHostException("no route")))
        assertTrue(isHardNetworkFailure(SSLHandshakeException("tls")))
        assertTrue(isHardNetworkFailure(IOException("wrapped", ConnectException("refused"))))
    }

    @Test
    fun `超时和 DNS 失败不换地址`() {
        assertFalse(isHardNetworkFailure(SocketTimeoutException("timeout")))
        assertFalse(isHardNetworkFailure(UnknownHostException("dns")))
        assertFalse(isHardNetworkFailure(IOException("other")))
    }

    @Test
    fun `从带子路径的外网切到内网时去掉前缀`() {
        val request = "https://example.com/movieclaw/api/v1/library?x=1".toHttpUrl()
        val current = "https://example.com/movieclaw".toHttpUrl()
        val alternate = "http://192.168.1.10:3300".toHttpUrl()

        assertEquals(
            "http://192.168.1.10:3300/api/v1/library?x=1",
            failoverUrl(request, current, alternate).toString(),
        )
    }

    @Test
    fun `从内网切回带子路径的外网时补上前缀`() {
        val request = "http://192.168.1.10:3300/api/v1/library?x=1".toHttpUrl()
        val current = "http://192.168.1.10:3300".toHttpUrl()
        val alternate = "https://example.com/movieclaw/".toHttpUrl()

        assertEquals(
            "https://example.com/movieclaw/api/v1/library?x=1",
            failoverUrl(request, current, alternate).toString(),
        )
    }

    @Test
    fun `两边都没有子路径时路径原样保留`() {
        val request = "http://192.168.1.10:3300/api/v1/images/proxy?url=a%2Fb&w=600".toHttpUrl()
        val current = "http://192.168.1.10:3300".toHttpUrl()
        val alternate = "https://movie.example.com".toHttpUrl()

        assertEquals(
            "https://movie.example.com/api/v1/images/proxy?url=a%2Fb&w=600",
            failoverUrl(request, current, alternate).toString(),
        )
    }
}
