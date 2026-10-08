package io.movieclaw.androidtv.core.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerDiscoveryTest {
    private fun reply(json: String, source: String = "192.168.1.10") = ServerDiscovery.parse(json.encodeToByteArray(), source)

    @Test
    fun parsesDiscoveryReplies() {
        val r = reply("""{"Address":"http://192.168.1.10:3000","Id":"x","Name":"客厅 NAS","EndpointAddress":null}""")
        assertEquals(ServerDiscovery.Reply("http://192.168.1.10:3000", "客厅 NAS", "192.168.1.10"), r)
        // 没有名字 / 名字为空 → 默认 MovieClaw
        assertEquals("MovieClaw", reply("""{"Address":"http://a:3000","Name":""}""")?.name)
        assertEquals("MovieClaw", reply("""{"Address":"http://a:3000"}""")?.name)
        // 不是发现应答
        assertNull(reply("""{"Name":"x"}"""))
        assertNull(reply("""{"Address":""}"""))
        assertNull(reply("who is JellyfinServer?"))
        assertNull(reply("[1,2]"))
    }

    @Test
    fun candidatesAreOrderedAndDeduplicated() {
        // 应答地址可用：它排第一；来源 IP + 端口与它相同就不重复
        assertEquals(
            listOf("http://192.168.1.10:3000"),
            ServerDiscovery.candidates(ServerDiscovery.Reply("http://192.168.1.10:3000", "m", "192.168.1.10")).map { it.toString() },
        )
        // 桥接部署：应答是容器内网 IP + 自定义端口 → 来源 IP + 应答端口 → 来源 IP + 3000
        assertEquals(
            listOf("http://172.17.0.2:8096", "http://192.168.1.10:8096", "http://192.168.1.10:3000"),
            ServerDiscovery.candidates(ServerDiscovery.Reply("http://172.17.0.2:8096", "m", "192.168.1.10")).map { it.toString() },
        )
        // 外部访问地址是不带端口的域名：端口按默认 3000 推
        assertEquals(
            listOf("https://mc.example.com", "http://192.168.1.10:3000"),
            ServerDiscovery.candidates(ServerDiscovery.Reply("https://mc.example.com/", "m", "192.168.1.10")).map { it.toString() },
        )
        // 应答地址写坏了：只剩来源 IP
        assertEquals(
            listOf("http://10.0.0.5:3000"),
            ServerDiscovery.candidates(ServerDiscovery.Reply("ftp://x", "m", "10.0.0.5")).map { it.toString() },
        )
    }

    @Test
    fun firstPassingFollowsCandidateOrder() {
        assertEquals("b", ServerDiscovery.firstPassing(listOf("a", "b", "c"), listOf(false, true, true)))
        assertNull(ServerDiscovery.firstPassing(listOf("a"), listOf(false)))
    }

    @Test
    fun subnetHostsStayWithinOneSlash24() {
        val ip = 0xC0A8010AL // 192.168.1.10
        val hosts = ServerDiscovery.subnetHosts(ip, 24)
        assertEquals(254, hosts.size)
        assertEquals("192.168.1.1", ServerDiscovery.dotted(hosts.first()))
        assertEquals("192.168.1.254", ServerDiscovery.dotted(hosts.last()))
        assertTrue(ip in hosts)
        // 公司网 /16 也只扫本机所在的 /24
        assertEquals(hosts, ServerDiscovery.subnetHosts(ip, 16))
        // /30 点对点：只有两个主机
        assertEquals(listOf("192.168.1.9", "192.168.1.10"), ServerDiscovery.subnetHosts(ip, 30).map(ServerDiscovery::dotted))
        assertEquals(emptyList<Long>(), ServerDiscovery.subnetHosts(ip, 32))
    }

    @Test
    fun onlyPrivateRangesAreScanned() {
        assertTrue(ServerDiscovery.isPrivate(0x0A000001L)) // 10.0.0.1
        assertTrue(ServerDiscovery.isPrivate(0xAC100001L)) // 172.16.0.1
        assertTrue(ServerDiscovery.isPrivate(0xAC1FFFFEL)) // 172.31.255.254
        assertFalse(ServerDiscovery.isPrivate(0xAC200001L)) // 172.32.0.1
        assertTrue(ServerDiscovery.isPrivate(0xC0A80001L)) // 192.168.0.1
        assertFalse(ServerDiscovery.isPrivate(0x08080808L)) // 8.8.8.8
        assertFalse(ServerDiscovery.isPrivate(0xC6120001L)) // 198.18.0.1（代理 fake-ip 段，不是 RFC 1918）
    }

    @Test
    fun healthBodyMustSayOk() {
        assertTrue(ServerDiscovery.isHealthy("""{"status":"ok","version":"0.33.0"}"""))
        assertFalse(ServerDiscovery.isHealthy("""{"status":"degraded"}"""))
        assertFalse(ServerDiscovery.isHealthy("""{"ServerName":"Jellyfin"}"""))
        assertFalse(ServerDiscovery.isHealthy("<html>"))
    }
}
